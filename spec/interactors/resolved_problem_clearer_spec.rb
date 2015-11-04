describe ResolvedProblemClearer do
  let(:resolved_problem_clearer) {
    ResolvedProblemClearer.new
  }
  describe "#execute" do
    let!(:problems) {
      [
        Fabricate(:problem),
        Fabricate(:problem),
        Fabricate(:problem)
      ]
    }
    context 'without problem resolved' do
      it 'do nothing' do
        expect {
          expect(resolved_problem_clearer.execute).to eq 0
        }.to_not change {
          Problem.count
        }
      end
      it 'not repair database' do
        allow(Mongoid.default_client).to receive(:command).and_call_original
        expect(Mongoid.default_client).to_not receive(:command).with({ repairDatabase: 1 })
        resolved_problem_clearer.execute
      end
    end

    context "with problem resolve" do
      before do
        allow(Mongoid.default_client).to receive(:command).and_call_original
        allow(Mongoid.default_client).to receive(:command).with({ repairDatabase: 1 })
        problems.first.resolve!
        problems.second.resolve!
      end

      it 'delete problem resolve' do
        expect {
          expect(resolved_problem_clearer.execute).to eq 2
        }.to change {
          Problem.count
        }.by(-2)
        expect(Problem.where(_id: problems.first.id).first).to be_nil
        expect(Problem.where(_id: problems.second.id).first).to be_nil
      end

      it 'repair database' do
        expect(Mongoid.default_client).to receive(:command).with({ repairDatabase: 1 })
        resolved_problem_clearer.execute
      end
    end
  end
end
